# Boat Plotter — Migration to x86 (CWWK N100)

> Read top-to-bottom when the box has arrived and you're SSH'd in, aiming for a one-pass rebuild.
> `[TODO-CONFIRM]` = needs a value from you/the boat before proceeding.
>
> **Shortcut:** once Debian is installed and this repo is on the box, `sudo ./n100/bootstrap.sh`
> does the mechanical half — packages, the un-packaged Python dep, config restore, dock build,
> udev, unit enablement — and prints what still needs hands. `--check` reports without changing
> anything. Everything below remains the reference for *why*.

## Pre-flight checklist — do these in order on the day

Print or keep this open; §0–15 is the reference, this is the running order.

**Before powering on (bench)**

> **Do not open the case yet.** Boot to the BIOS first and look for the COM mode there (§6) — it is
> often a BIOS setting, not a jumper. And even if jumpers *are* needed, they do **not** block the
> build: N2K arrives over USB, so everything can be installed and validated first.

- [ ] **BIOS → *Restore AC Power Loss* = `Power On`** (a.k.a. *After Power Loss*, *AC Power
      Recovery*, *State After G3*). **Auto power-up — the single most important setting here.**
      Boat DC gets switched at the breaker and the battery isolator; without this the plotter stays
      dead until someone presses the button. The Pi booted on power; a PC does not. **Verify by
      pulling the DC plug, not by trusting the menu.** (§1)
- [ ] BIOS → **Secure Boot = Disabled** (§1)
- [ ] BIOS → **Intel VMD / RST = Disabled** — otherwise the installer sees **no disk** (§1)
- [ ] BIOS → **Fast Boot = Disabled**, boot order USB first (§1)
- [ ] **COM RS485 mode** — check the **BIOS** first (§6); jumpers only if the BIOS has no option.
      Not build-blocking: N2K arrives over USB.
- [ ] BIOS reports **8 GB RAM** and the **128 GB NVMe** before closing up

**Install**
- [ ] USB keyboard + installer stick, **F7/F11 → the entry starting `UEFI:`** (§1)
- [ ] *Guided — use entire disk* (this erases the unlicensed Windows; no licence involved) (§1)

**On the fresh Debian**
- [ ] **Set up key-based SSH + passwordless sudo** so the Mac can drive the rest (§1.6)
- [ ] `sudo ./n100/bootstrap.sh` then `sudo ./n100/install-apps.sh` (§1–2)
- [ ] Signal K first login; N2K connection → SocketCAN → `can0` (§5)
- [ ] Both RS485 inputs, **listen-only**: 4800 and 38400 (§6)
- [ ] Appstore: KIP, `signalk-to-nmea2000` + Wind(130306), `signalk-shelly2` + units patch (§2)
- [ ] AvNav chart re-licence (encrypted, machine-bound) (§3)
- [ ] `rclone config` for the Dropbox manuals (§15 / `pi-dock/dropbox/`)
- [ ] Tailscale: login, approve subnet route, **disable key expiry** (§11)

**Accept**
- [ ] `ip -details link show can0` → UP, ERROR-ACTIVE, 250000 (§10)
- [ ] Transmitted 130306 appears from the plotter's own source address (§10)
- [ ] **Unattended power-cycle: pull DC, restore, everything returns on its own** (§10)
- [ ] 24–48 h soak

---

## 0. Hardware & architecture

- **CWWK Fanless Industrial Mini PC** — Intel **N100**, **8 GB RAM**, **128 GB M.2 NVMe** (included),
  **2× DB9 COM (RS232/RS485, jumper-switchable — set both to RS485, listen-only; §6)**, dual
  **2.5 GbE i226-V**, 2× HDMI + DP + USB-C, SIM slot, M.2 E-key, **12 V DC in**.
- **Shipped state:** unlicensed **Windows 11** preinstalled, Secure Boot on. Irrelevant — the NVMe
  gets overwritten, no licence or "upgrade path" involved — but the BIOS needs three settings
  first, one of them critical (§1).
- **CAN / NMEA 2000:** CANable2 USB-CAN (STM32G431CB), **candlelight** firmware → kernel
  `gs_usb` → `can0`. Already re-flashed from slcan; see §5.
- **Second Wi-Fi:** the AIC8800 USB dongle (BoatNetwork AP).
- **Display:** existing HDMI touchscreen (ILITEK 222A:0001) — USB touch + HDMI.
- **Spare:** old 256 GB X15 NVMe is *not* boot; keep as spare.

**Decision: plain Debian 13 amd64 + Signal K + AvNav + KIP. No OpenPlotter, no OpenCPN**
(AvNav replaces OpenCPN; it talks to Signal K directly over WebSocket).

**USB port budget — plan it before the lid goes on.** Three permanent USB devices plus a temporary
one during the build, so know which port is which and label them:

| Device | Permanent? | Notes |
|---|---|---|
| **CANable2** (N2K gateway) | yes | needs a **USB 2.0** port if available — it's a 12 Mb/s full-speed device and some USB 3 controllers are fussy with `gs_usb` |
| **AIC8800 Wi-Fi dongle** (BoatNetwork AP) | yes | the onboard Wi-Fi is the **uplink**; this dongle is the access point (§8). Confirm it comes up as `wlan1` |
| **HDMI touchscreen USB touch** | yes | ILITEK 222A:0001 |
| **USB keyboard** | build only | unplug when done; the touchscreen can't drive the installer |

If the box is short of ports, the dongles can share a powered hub — but keep the **CANable2 on a
direct port**, not behind a hub, to avoid `gs_usb` enumeration problems. Record the final mapping
and label the ports once it's built; a dongle in the wrong socket on a dark boat is a bad evening.

---

## 1. OS install

> ⚠️ **Open issue, confirmed on the unit (2026-11-18): `State After G3` / *Restore AC Power Loss* was
> NOT found.** Searched Advanced (no Power Management or PCH-IO entry) and Chipset → PCH-IO
> Configuration (PCIe/SATA/USB/SerialIo/PMC/DeepSx — `DeepSx Power Policies` is already *Disabled*,
> which is the ErP-adjacent setting). Deferred: get the system working first. Options to revisit, in
> order: `Chipset → PCH-IO → PMC Configuration` and `Advanced → PCH-FW Configuration`; then
> `Advanced → S5 RTC Wake Settings` as a timed-wake workaround; failing all that, a hardware answer at
> the boat end (latching relay or UPS power-good signal). **Until resolved, a DC power cut leaves the
> plotter off until someone presses the button.**

> **Observed on the actual unit (CWWK N100, AMI Aptio).** `Advanced` holds: CPU Configuration,
> Power & Performance, PCH-FW Configuration, Trusted Computing, **IT8625 Super IO Configuration**,
> Hardware Monitor, S5 RTC Wake Settings, Network Stack Configuration, CSM Configuration, NVMe
> Configuration. Note there is **no** *Power Management* or *PCH-IO* under Advanced — "Power &
> Performance" is CPU power/limits and is **not** AC-power behaviour. The AC-loss setting lives under
> the **Chipset** tab. The **IT8625** entry is the Super I/O chip that owns COM1/COM2, so the
> RS232/RS485 mode should be a BIOS option there rather than a board jumper (§6).

**If `Del` does not enter the BIOS, do not fight the timing.** With Windows still installed, reboot
straight into the firmware from Windows — no key presses needed:

```
shutdown /r /fw /t 0          # MUST be an elevated prompt
```

**`Error 1314: A required privilege is not held by the client`** means the prompt is *not* elevated —
use **Win+X → Terminal (Admin)**, not the Start-menu Command Prompt. If elevation is a hassle, skip
it: **Start menu → power icon → hold `Shift` → Restart → Troubleshoot → Advanced options → UEFI
Firmware Settings → Restart** needs no admin at all.

or *Settings → System → Recovery → Advanced startup → Restart now → Troubleshoot → Advanced options
→ UEFI Firmware Settings*. If `/fw` reports "not supported", use the GUI route.

Why the key fails: **Fast Boot initialises USB too late** for the BIOS to see the keyboard — a
chicken-and-egg, since Fast Boot must be turned off from inside the BIOS. Also note **Windows Fast
Startup** makes "Shut down" a partial hibernate, so powering on from it skips POST entirely and no
key can register: always use **Restart**, or Shift+Restart. A keyboard that works in Windows can
still be invisible to POST if it is on a **USB 3 port or a hub** — try a wired keyboard on a rear
USB 2.0 port, and also try `F2`, `F7`, `F11`, `Esc`.

**Before anything else — BIOS.** These units ship with **Windows 11 preinstalled** (the OEM key
lives in the BIOS) and **Secure Boot enabled**. The Windows install is irrelevant — step 1 wipes
the NVMe — but the BIOS settings are not, and two of them bite only later, on the boat, if missed:

| Setting | Menu (AMI BIOS, `Del` at power-on) | Set to | Why |
|---|---|---|---|
| **`State After G3`** — a.k.a. *Restore AC Power Loss*, *AC Power Recovery*, *After Power Loss*. **On this board: `Chipset → PCH-IO Configuration`** (right pane reads *"state to go to when power is re-applied after a power failure (G3 state)"*) | Chipset | **`S0 State`** (Power On) | **The most important setting on this box.** Boat DC gets cut — breaker, battery switch, brownout. Without it the plotter stays dead until someone physically presses the button, which is no use at anchor or underway. The Pi did this by default; the PC does not. |
| **ErP / EuP Ready**, also `Deep Sx` | same menu as above | **Disabled** | Energy regs mode cuts standby power and **silently defeats auto power-up** (and Wake-on-LAN). If *Restore AC Power Loss* is set to Power On but the box still won't start, this is almost always why. |
| **Wake on LAN** (optional) | Advanced / Power Management | Enabled | lets you wake it over the network; pairs with ErP disabled |
| **Secure Boot** | Security / Boot | **Disabled** | Debian netinst won't boot otherwise |
| **Intel VMD / RST** (if shown) | Advanced → System Agent / Storage | **Disabled** | if left enabled the Debian installer sees **no disk at all** — a known N100 trap |
| **Fast Boot** | Boot | **Disabled** | so the USB stick appears in the boot menu |
| Boot order | Boot | **USB first** | |
| **WDT / hardware watchdog** | Advanced | note its location | optional, not needed (§5/`can-watchdog` covers the CAN side) |

While the lid is off, also move **both COM jumpers to RS485** (§6) — that's a board jumper, not a
BIOS option. Confirm the BIOS reports **8 GB RAM** and the **128 GB NVMe** before closing up.

**Prove the auto power-up before you go any further:** with everything closed up, pull the DC plug,
wait ten seconds, plug it back in. The box must start *by itself*. If it doesn't, one of the two
settings above is wrong — find out now, on the bench, not at anchor. This is checked again in §10.

**Getting Debian onto it — the Windows install is a red herring.** Nothing here needs a licence, an
"upgrade" or a conversion: the installer **overwrites** the NVMe. The preinstalled build is almost
certainly KMS/"activated" rather than genuinely licensed — not something to put on a boat network
even if you wanted to keep it, and it's about to be erased anyway.

Build the USB stick (any ≥ 1 GB stick). This is **amd64**, *not* arm64 — Raspberry Pi imaging
tools will default to the wrong architecture, so write the raw ISO:

```
# on the Mac
curl -LO https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso
# (if that 404s by the time the box arrives, open
#  https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ and take the newest netinst)
shasum -a 256 debian-13.7.0-amd64-netinst.iso     # expect a7ef94ac...67e355
diskutil list                                      # identify the stick - check its size twice
diskutil unmountDisk /dev/diskN
sudo dd if=debian-13.7.0-amd64-netinst.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

Then on the N100: HDMI touchscreen and a **USB keyboard** plugged in (touch alone isn't enough for
the installer), stick in, power on, one-time boot menu (**F7** or **F11**; `Del` = BIOS) and pick
the entry prefixed **`UEFI:`** — this must be a UEFI install, not legacy/CSM. In the installer
choose **“Guided — use entire disk”**, which removes Windows and its recovery partitions in one go.

If the stick never shows up: re-check Fast Boot and Secure Boot are off, try a different USB port,
and confirm you wrote to the stick you think you did. If the BIOS is locked with a seller password,
clear CMOS via the board jumper.

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
     libgtk-3-dev libgtk-layer-shell-dev gcc pkg-config python3 python3-pip \
     bluez pipewire pipewire-pulse can-utils jq picocom chromium nodejs nginx rclone
   ```
   **`dock.c` is GTK3** — confirmed, not a guess: it calls `gtk_init()` and
   `gtk_window_new(GTK_WINDOW_TOPLEVEL)`, both removed in GTK4, and includes
   `<gtk-layer-shell.h>` (GTK3 header; GTK4's is `gtk4-layer-shell.h`). So the
   packages are `libgtk-3-dev` + **`libgtk-layer-shell-dev`**.
   ⚠️ *Not* `libgtk3-layer-shell-dev` — that name does not exist in Debian and apt
   will refuse it. (Beware: packages.debian.org answers HTTP 200 for non-existent
   packages, so a status-code check lies. Verify by the page body.)
5. **Python dependency Debian doesn't package:** `set-timezone.py` imports `timezonefinder`,
   which is **not** in Debian 13 (`python3-timezonefinder` does not exist). Without it
   `set-timezone.timer` fails every 10 minutes:
   ```
   sudo python3 -m pip install --break-system-packages timezonefinder
   ```
   This drags in `numpy` (~20 MB) — expected. Quick check:
   `python3 -c "import timezonefinder; print('ok')"`.
6. **Remote access for the build — do this before handing over.** The box is driven from the Mac
   over the LAN, so it must accept **key** auth (an interactive password prompt cannot be answered
   by automation) and allow **passwordless sudo** (every build step is `sudo`). The old Pi was set up
   exactly this way — `pi-dock/README.md` records `pi` with passwordless sudo — so this is
   precedent, not a new exposure.

   Confirm **openssh-server** is installed (tick *SSH server* in the installer's tasksel screen, or
   `sudo apt install -y openssh-server`). Then, **on the Mac**, one interactive step:

   ```
   ssh-copy-id -i ~/.ssh/id_ed25519.pub pi@192.168.1.50
   ssh pi@192.168.1.50       # password once, then set up sudo:
     echo "pi ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/010-pi-nopasswd
     sudo chmod 440 /etc/sudoers.d/010-pi-nopasswd
     exit
   ```

   Proof it worked — this must return silently with no prompt:

   ```
   ssh -o BatchMode=yes pi@192.168.1.50 'sudo -n true && echo READY'
   ```

   `READY` means the remaining work can be scripted end to end. If that line prompts or errors,
   fix it now rather than mid-build: a password prompt is exactly what blocks automation.

---

## 2. Signal K

1. **Node 22 first — this is a hard prerequisite, not an optional upgrade.** Debian 13 ships
   **nodejs 20.19.2**, but Signal K **2.37 requires Node ≥ 22** (`engines: node >=22`), so
   installing Signal K from Debian's Node simply fails. Add the NodeSource repo:
   ```
   curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
   sudo apt install -y nodejs
   node --version        # must be v22.x or newer
   ```
   This also fixes `inject-kip.mjs` (§2.10), which needs a global `WebSocket` that Node 20 lacks.

2. Install Signal K from npm:
   ```
   sudo npm install -g signalk-server --allow-scripts=@canboat/canboatjs
   sudo signalk-server-setup      # interactive: port 3000, enables the service
   ```
   ⚠️ The old `raw.githubusercontent.com/.../bin/install.sh` one-liner **no longer exists** (404).
   npm is now the supported path.
3. Restore data (from this repo checkout):
   ```
   sudo cp -a pi-dock/pi-config/home/pi/.signalk/. /home/pi/.signalk/
   sudo chown -R pi:pi /home/pi/.signalk
   ```
   Restores KIP dashboards (`applicationData/users/boat/kip/11.0.0.json`), plugin configs
   (`derived-data.json`, `holdingtank-status.json`, `signalk-shelly2.json`), and the
   `holdingtank-status` plugin code.
4. Register `holdingtank-status` in `/home/pi/.signalk/package.json` dependencies, restart signalk.
5. First login: create user **`boat`** / **`bossy`** (admin).
   Recreate `/etc/signalk-automation.env` from `signalk-automation.env.example` (chmod 600).
6. **Install KIP** — the kiosk UI the dock's "Engine" button opens, served by Signal K itself at
   `/@mxtommy/kip/`. From *Appstore → Webapps* install **KIP** (mxtommy); it lands in
   `~/.signalk/node_modules` and needs no separate server. Then:
   - open `http://localhost:3000/@mxtommy/kip/` and confirm the app loads;
   - the surviving `default` helm dashboard is restored by step 2; the **Engine** dashboard is
     restored by step 8 below;
   - the other ~3 dashboards were lost with the Pi — rebuild them by hand in the KIP UI (see
     `pi-dock/kip/DASHBOARDS.md` for what existed).
7. Install **`signalk-to-nmea2000`** from *Appstore → Signal K plugins*, and enable its
   **`Wind (130306)`** conversion. This is what makes the plotter *transmit* on the N2K bus
   (§5) — without it Signal K only listens. Plugin config isn't captured by `snapshot-pi.sh`,
   so it's a one-off UI setup.
8. **Two repo-only extras that `snapshot-pi.sh` never captured** — both were missing from this doc
   until it was audited, and neither is discoverable from the running box:
   - **`signalk-plugins/fuel-economy`** — rolling L/NM from (port + starboard) fuel rate and SOG,
     published to `propulsion.main.fuel.economy`. Copy into
     `/home/pi/.signalk/node_modules/signalk-fuel-economy` and add it to the `package.json`
     dependencies alongside `holdingtank-status`, then restart Signal K.
   - **`signalk-zones/set-zones.py`** — writes `meta.zones` for the gauge bands. Run **once** after
     Signal K is live; it talks to `http://localhost:3000/signalk/v1/api/vessels/self` with no auth
     when run on the box itself: `python3 signalk-zones/set-zones.py` then restart Signal K so the
     KIP gauges pick the zones up.
9. **Plugin inventory.** Restoring `plugin-config-data/` restores a plugin's *settings* — it does
   **not** install the plugin. Each of these must be installed, then Signal K restarted:

   | Plugin | From | Post-install |
   |---|---|---|
   | `signalk-to-nmea2000` | Appstore | enable **Wind (130306)** — this is the N2K *transmit* path (§5) |
   | `signalk-derived-data` | Appstore | true wind etc.; settings come back from `derived-data.json` |
   | `signalk-shelly2` | Appstore | **re-apply the `units:bool` patch** (§9) after every reinstall |
   | `holdingtank-status` | **this repo** (`pi-config/home/pi/.signalk/node_modules/`) | add to `package.json` deps (§2.4) |
   | `signalk-fuel-economy` | **this repo** (`signalk-plugins/`) | copy in + add to `package.json` deps |

   Only the first three are downloadable; the last two are custom and exist only here.

   ⚠️ A custom plugin **must define `plugin.schema`** (even `{}`). Signal K 2.x refuses to load one
   without it — `fuel-economy` shipped without and silently never ran. Fixed in the repo.

   **The restored config already carries the enabled flag** — `derived-data.json`,
   `holdingtank-status.json` and `signalk-shelly2.json` all contain `"enabled": true`. So once a
   plugin is *installed*, restoring `plugin-config-data/` (§2.3) switches it on for you; there is no
   need to toggle it in the UI. Restart Signal K after installing rather than before.
10. **Restore the `Engine` KIP dashboard** (the other survivor — the `default` helm dashboard comes
   back with `.signalk` above). This one does **not** live in `.signalk`; it's `pi-dock/kip-config.json`,
   pushed into the KIP kiosk's Chromium *localStorage* over CDP. Nothing in §4 restores it, because
   the files sit in `pi-dock/`, not in `pi-config/`:
   ```
   sudo cp pi-dock/kip-config.json pi-dock/inject-kip.mjs /home/pi/
   sudo chown pi:pi /home/pi/kip-config.json /home/pi/inject-kip.mjs
   ./pi-dock/inject-kip.sh          # headless Chromium + CDP, then restores the kiosk
   ```
   Both paths are hard-coded to `/home/pi/` in `inject-kip.mjs` and `inject-kip.sh`, so don't
   relocate them. Two prerequisites, both easy to miss:
   - **`nodejs`** must be installed — it normally arrives with Signal K; `inject-kip.sh` calls
     `node`. If missing: `sudo apt install nodejs`.
   - **`inject-kip.mjs` uses a global `WebSocket`**, which exists in Node **21+ (experimental) /
     22+ (stable)** but **not** in Node 20. `[TODO-CONFIRM]` which Signal K pulls in; if the
     script exits at *"ws not open"*, that's the cause — `node --version` and upgrade if it's 20.
   Verify: the Engine button shows four port-engine gauges (§7), not a blank KIP page.

   `signalk-fuel-economy` reads `propulsion.port.fuel.rate` and `propulsion.starboard.fuel.rate`
   (m³/s, summed) plus `navigation.speedOverGround`, and publishes `propulsion.main.fuel.economy`
   (L/NM) over a rolling 30 s window, suppressed below ~1 kn (0.5 m/s SOG). It therefore requires the
   two engines at the **named** instances `propulsion.port` / `propulsion.starboard` — if the N2K
   gateway exposes numeric instances (`propulsion.0` / `propulsion.1`), map them accordingly. No
   plugin settings exist; whether it was ever verified against live data is `[TODO-CONFIRM]`.

---

## 3. AvNav (no OpenCPN)

1. AvNav is not in Debian — add the **oss.boating** repo (this is the real one; the
   `wellenvogel.net/software/avnav/deb` path some guides cite is **404**):
   ```
   curl -fsSL https://www.free-x.de/debian/oss.boating.gpg.key \
     | gpg --dearmor | sudo tee /usr/share/keyrings/oss.boating.gpg >/dev/null
   echo "deb [signed-by=/usr/share/keyrings/oss.boating.gpg] https://www.free-x.de/debian trixie main contrib non-free" \
     | sudo tee /etc/apt/sources.list.d/boating.list
   sudo apt update && sudo apt install -y avnav
   ```
   Suite **`trixie`** carries `amd64`. Port **8080**.
2. If it fails on `python3-bluez`: `sudo apt install -y python3-bluez`.
3. Charts — **do not skip this**. AvNav with an empty chart directory never finishes
   loading: the chart-list dialog spins on "Fetching Chartlist …" forever, because the
   list only stops loading once it contains at least one chart. It looks like a network
   hang; it is not. Two independent chart sources are needed:

   **3a. Base chart** — generated locally from Natural Earth (public domain, so bulk
   generation raises no tile-server usage-policy problem). It gives coastline, borders,
   lakes and place names for orientation, and is **not for navigation**:
   ```
   sudo apt install -y python3-numpy python3-pil python3-shapefile python3-certifi
   sudo ./n100/make-base-chart.py --bbox -6,29,37,47 --zoom 0-9 \
        --out /tmp/med-base.mbtiles --name "Mediterranean base (Natural Earth)"
   sudo install -o avnav -g avnav -m 644 /tmp/med-base.mbtiles /var/lib/avnav/charts/
   ```
   `--bbox -6,29,37,47` is the Mediterranean; change it for other cruising grounds
   (2,818 tiles, ~10 min). Rendering again when the boat moves is cheaper than carrying
   world-wide zoom levels.

   **3b. o-charts (oeSENC)** — `avnav-ochartsng` comes from the same oss.boating repo and
   registers itself as the `system-ochartsng` provider (port 8083). Its charts live in
   **`/var/lib/avnav/ochartsng/charts`**, not in the normal chart directory, so they do not
   appear in `/var/lib/avnav/charts`. Check it is alive with
   `curl -s http://localhost:8083/status` → `"state":"READY"`.

   The licence is bound to a hardware fingerprint, so the bought set must be **re-issued**
   after the hardware change (this is the one unavoidable re-activation):
   1. Get the fingerprint — plugin GUI (Apps → Ocharts-Provider → Charts → "Get Fingerprint")
      or headless: `curl -s "http://localhost:8083/shop/fpr?forDownload=true" -o bossy.fpr`
      (~337 bytes; it is deliberately obfuscated, do not edit it).
   2. Upload it at <https://o-charts.org/shop/en/module/occharts/occhartsOesu> and give the
      system a name, e.g. `bossy-n100`. Up to 5 systems per account — the old Pi system can
      stay registered.
   3. Assign the already-bought chart to the new system and request the download mail.
   4. Download the zip and upload it in the plugin GUI with "Upload Zip". No restart needed
      with ochartsng.
4. If AvNav fails to install on `python3-bluez`: `sudo apt install -y python3-bluez`.

---

## 4. Restore the Pi config (with the x86 delta)

```
sudo cp -a pi-dock/pi-config/etc/. /etc/
sudo cp -a pi-dock/pi-config/usr/. /usr/
sudo cp -a pi-dock/pi-config/home/. /home/
sudo cp -a pi-dock/pi-config/var/. /var/
sudo systemctl daemon-reload
```

> ⚠️ Don't skip the `var/` line. `pi-dock/pi-config/var/lib/avnav/avnav_server.xml` holds the
> AvNav server config (chart directories, port, settings) and is the one file the original
> three-line version of this section silently dropped. `boot/` is deliberately **not** restored —
> it's Pi `config.txt`/`cmdline.txt`, and x86 uses GRUB (§1.3).

**Enable:**
```
sudo systemctl enable can0-nmea2000.service can-watchdog.timer \
  shelly-watchdog.timer holding-tank-dump.service cockpit-light.service \
  memwatch.timer set-timezone.timer bt-hifi.service manuals-sync.timer
```

> **Do not enable `boatnetwork.service` / `boatnetwork-dnsmasq.service`.** Those were the
> Pi's hostapd + dedicated-dnsmasq pair on `wlan1`. On the N100 the AP is owned by
> NetworkManager (§8.2) and the standalone `dnsmasq` service must stay **masked**, otherwise
> its empty config holds `0.0.0.0:53` and the AP activation fails outright.

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
2. `can0-nmea2000.service` must **not** use `restart-ms`. The CANable2 in candleLight
   (`gs_usb`) mode rejects it with *"Device doesn't support restart from Bus Off"*, the
   unit fails, `can0` never comes up and Signal K sees nothing. Split the two calls:
   ```
   ExecStart=/sbin/ip link set can0 type can bitrate 250000
   ExecStart=/sbin/ip link set can0 up
   ```
   **Do not** add `After=dev-can0.device` / `Wants=dev-can0.device`. `dev-can0.device`
   is `/dev/can0`, which does not exist for a network interface — systemd queues a job
   that can never complete and the whole boot **hangs** (`multi-user.target`,
   `signalk.service` and everything else stay `waiting`). The correct unit name would be
   `sys-subsystem-net-devices-can0.device`, but don't rely on it. Use instead:
   - an `ExecStartPre` loop that waits up to 10 s for `ip link show can0`
   - a udev rule so the unit also runs when the adapter is **plugged in** later:
     ```
     # /etc/udev/rules.d/62-can0-nmea2000.rules
     ACTION=="add", SUBSYSTEM=="net", KERNEL=="can0", TAG+="systemd", \
       ENV{SYSTEMD_WANTS}+="can0-nmea2000.service"
     ```
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

**The N2K connection, exactly as Signal K stores it.** Adding it by hand is fiddly because the
element needs `options.type` = `NMEA2000` *and* the device in `subOptions`; get either wrong and
Signal K logs `Unknown data type for undefined` and the provider never starts. The working block in
`/home/pi/.signalk/settings.json`:

```json
"pipedProviders": [{
  "id": "n2k-can0",
  "enabled": true,
  "pipeElements": [{
    "type": "providers/simple",
    "options": {
      "type": "NMEA2000",
      "subOptions": { "type": "canbus-canboatjs", "interface": "can0",
                      "uniqueNumber": 31415, "mfgCode": 999 }
    }
  }]
}]
```

It can be added without the UI: `PUT/POST http://localhost:3000/skServer/providers` (note the
`/skServer` prefix, **not** `/skAdmin`). Success appears in the log as
`Successfully connected to can0`.

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

**Both ports are LISTEN-ONLY (receive only).** Nothing is ever driven back out onto those
pairs: no half-duplex turnaround, no contention with the instruments, and no way to accidentally
transmit into instrument wiring. The consequence is simply that Signal K must be configured
**input-only** on both, and these ports can never feed an autopilot or any other NMEA 0183 sink.
All transmission in this build goes out over NMEA 2000 (§5), not 0183.

| Port | Device | Rate | Feeds |
|---|---|---|---|
| COM 1 | `/dev/rs485-1` | **4800 8N1** | general instrument data (classic NMEA 0183) |
| COM 2 | `/dev/rs485-2` | **38400 8N1** | AIS (the conventional AIS rate) |

1. **RS232/RS485 mode — check the BIOS before opening the case.** On many CWWK/AMI industrial
   boards the mode is a **BIOS setting**, not a jumper: `Advanced → Serial Port Configuration` (or
   a SuperIO / IT8786 submenu) exposing *Serial Port 1/2 Mode* = `RS232` / `RS485` / `RS422`.
   Look there first. Only if it is absent are physical jumpers involved — a 2–3 pin header near the
   DB9s, often labelled `J1`/`J2` or `485`.
2. **This does not block the build.** NMEA 2000 arrives over USB (the CANable2 → `can0`), so the
   whole system can be built, validated and soaked with the COM ports still in RS232 mode. The
   ports only matter once NMEA 0183 instruments and AIS are physically connected.
   Wiring is the A/B differential pair plus signal ground; short runs, so no bus termination.
   Fallback if the ports cannot be switched: a USB→RS485 adapter per port, at the cost of two USB
   sockets — see the port budget in §0.
3. Signal K → *Data Connections → Add → Serial* per port, **input only**:
   - `/dev/rs485-1` @ 4800 8N1
   - `/dev/rs485-2` @ 38400 8N1
4. `[TODO-CONFIRM]` if a port stays silent, the port↔instrument mapping is reversed or the rate
   differs — try the other COM and the other rate before assuming a wiring fault.

---

## 7. Kiosk, dock & full app inventory

Rebuild the dock:
```
gcc dock.c -o pi-dock $(pkg-config --cflags --libs gtk+-3.0 gtk-layer-shell-0)
sudo install -m 755 pi-dock /usr/local/bin/pi-dock
```
`/etc/xdg/labwc/autostart` launches `pcmanfm`, `pi-dock`, `kanshi`, `squeekboard`, then
`launch-avnav.sh`. ⚠️ The Pi version used **`lwrespawn`, `pcmanfm-pi` and
`lxsession-xdg-autostart`** — none of those exist on Debian amd64, so the file is rewritten in this
repo to call the real binaries directly. Verify with:
`for b in $(grep -oE '/[a-z0-9/_-]+\.sh|/[a-z0-9/_-]+(?=\s|&|$)' /etc/xdg/labwc/autostart | sort -u); do [ -x "$b" ] || echo "MISSING $b"; done`

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
| Manuals (optional) | `launch-manuals.sh` | nginx on `:8081` + Dropbox sync — `pi-dock/dropbox/README.md`. Add to `dock.c` (1 line) to show the button |
| Bluetooth | `bt-pair.sh` / `bt-hifi.service` | bluez + pipewire (§1.4) |
| Power | `poweroff.sh` | nothing — just `poweroff` |

- `launch-plotter.sh` = fullscreen plotter window (AvNav). Update ports in the launch scripts if the new box serves on different ones.
- Touchscreen: USB HID touch + HDMI on Intel i915 — out of the box.

### 7.1 The dock must not cover AvNav's bottom bar

`dock.c` reserves 64 px with `gtk_layer_set_exclusive_zone`. **wlroots only honours an
exclusive zone on the `TOP`/`BOTTOM` layers.** On `LAYER_OVERLAY` the zone is ignored, the
dock paints over the last 64 px of whatever is behind it, and AvNav's whole bottom data
panel (DTG/ETA/BRG/SOG/WPT/POS) disappears underneath it. Two changes are needed together:

- `dock.c`: `GTK_LAYER_SHELL_LAYER_TOP`, not `..._LAYER_OVERLAY`
- `kiosk-launch.sh`: `--start-maximized`, not `--start-fullscreen`. A fullscreen window
  covers the entire output and ignores the exclusive zone regardless of layer.

Rebuild the dock and relaunch AvNav, then confirm with `grim`:

```
sudo gcc pi-dock/dock.c -o /usr/local/bin/pi-dock \
    $(pkg-config --cflags --libs gtk+-3.0 gtk-layer-shell-0)
```

### 7.2 Boot presentation — splash instead of scrolling text

`n100/install-splash.sh` installs Plymouth with the Fairline crest
(`n100/plymouth/splash.png`, generated 1920×1200 from
`pi-dock/Fairline Nautical Crest Logo.png`) and silences the console:

- `GRUB_TIMEOUT=0` + `GRUB_TIMEOUT_STYLE=hidden` — no menu
- `quiet splash loglevel=3 vt.global_cursor_default=0` — no kernel text, no cursor
- the splash is drawn on a **light** background because the crest and wordmark are navy

Verify after a reboot: `journalctl -b | grep -c plymouth` is non-zero and
`systemctl --failed` is empty.

### 7.3 The boot bell

The N100's Super I/O drives a PC speaker and the kernel loads `pcspkr`, so the console
bell sounds on every login. Two files silence it:

- `/etc/modprobe.d/nobeep.conf` — `blacklist pcspkr`, `blacklist snd_pcsp`
- `home/pi/.bash_profile` — `setterm -blength 0`

`.bash_profile` **and** the `getty@tty1` autologin drop-in live in `pi-config/`; they were
previously created by hand on the box only, so a restore used to lose kiosk autostart
entirely.

---

## 8. Wi-Fi: uplink + BoatNetwork AP (two radios)

The N100 has **one** onboard radio, and it cannot do both jobs. Verified with
`iw phy phy0 info`: the RTL8821CE (`rtw_8821ce`, PCI `03:00.0`) lists
`managed` and `AP` under supported modes but reports **no valid interface
combinations**, so it will not act as a station and an AP at the same time.
(The "two antennas" on the case are one Wi-Fi + one Bluetooth on that same
combo card — not two adapters.)

So the split is:

| Radio | Role | Why |
|---|---|---|
| Onboard RTL8821CE (`wlp3s0`) | uplink to Bossywifi / Starlink | in-chassis antenna, needs the range |
| USB AIC8800D80 (`wlx…`) | BoatNetwork AP | clients (Shelly, sensors) are metres away |

### 8.1 Driver for the USB adapter

Debian 13 has no in-kernel driver for the AIC8800. Run
`n100/install-wifi-dongle.sh`.

Two traps, both silent:

1. `a69c:8d80` is only the **firmware-download stage**. After `aic_load_fw`
   runs, the dongle re-enumerates as **`368b:8d83`**. Radxa's tree does not know
   that ID — its probe fails with `failed with errno 0` and you get no
   interface. Use `shenmintao/aic8800d80`, which defines
   `USB_PRODUCT_ID_AIC8800M80_CUS1 0x8D83`.
2. On Radxa's tree the firmware lands in `/lib/firmware/aic8800_fw/USB/` while
   the driver looks in `/lib/firmware/aic8800D80/`, giving
   `wrong size of firmware file`. Delete **all** `aic8800*` firmware dirs before
   installing — a stale mix can hang the chip.

Confirm success with two phys and two interfaces:

```
ls -d /sys/class/ieee80211/*      # phy0 + phy1
ip -br link | grep '^wl'          # wlp3s0 + wlx…
```

### 8.2 The AP

`n100/setup-boatnetwork.sh` creates it through NetworkManager:

```
sudo PASS='<passphrase>' ./n100/setup-boatnetwork.sh
```

- SSID `BoatNetwork`, WPA2/CCMP, 2.4 GHz channel 6, `autoconnect yes`
- box at **`192.168.10.1/24`** — this must stay on the old Pi subnet, because
  the Shelly devices hold static `192.168.10.x` addresses (`.151` holding tank,
  `.142` cockpit light)
- DHCP `192.168.10.100–200`, 1 h leases, DNS forwarded upstream
- the passphrase is **not** in this repo; it lives only in
  `/etc/NetworkManager/system-connections/BoatNetwork.nmconnection`

**The dnsmasq trap.** `bootstrap.sh` installs the `dnsmasq` package, whose
service starts with an empty config and grabs `0.0.0.0:53`. NetworkManager
runs its *own* dnsmasq for `ipv4.method shared`, which then fails with
`failed to create listening socket for …: Address already in use` and the
whole AP activation aborts. The script masks the standalone service:

```
systemctl disable --now dnsmasq && systemctl mask dnsmasq
```

`hostapd` is masked for the same reason — it is the Pi's mechanism and would
fight NetworkManager for the interface.

The Pi's own `boatnetwork.service`, `boatnetwork-dnsmasq.service`,
`/etc/hostapd/`, `/etc/default/hostapd` and
`NetworkManager/conf.d/boatnetwork-unmanaged.conf` have been **removed from
`pi-config/`**, so a restore no longer reinstalls an implementation that is
enabled-but-broken on x86.

### 8.3 Check it

```
sudo nmcli device wifi list ifname wlp3s0 | grep BoatNetwork   # beacon
ip -br addr show wlx…                                          # 192.168.10.1
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.1:3000/signalk
```

A client on `BoatNetwork` reaches Signal K at `192.168.10.1:3000` and AvNav at
`192.168.10.1:8080`.

### 8.4 If the onboard card is impossible to use as an uplink

Starlink Gen 3 routers have two Ethernet ports (Gen 2 needs the Ethernet
adapter). Wiring the plotter to one of those makes Ethernet the uplink, leaves
the onboard card entirely free for the AP, and removes the dongle from the
critical path.


---

## 9. Shelly automation

- **Install `signalk-shelly2` from the Appstore first** (see the plugin inventory in §2.9). Restoring
  `plugin-config-data/signalk-shelly2.json` only brings back its settings, not the plugin.
- Then re-apply the **`units:bool` patch** to `signalk-shelly2`'s `dist/components/SwitchBase.js`
  (one-line removal; `pi-dock/signalk-shelly2-state-units.patch`). This must be repeated after
  **every** plugin reinstall — an update silently reverts it and the switches report wrong units.
- Shelly devices unchanged (`.151` holding tank, `.142` cockpit light). Both daemons
  (`holding-tank-dump.py`, `cockpit-light.py`) use only Python's stdlib and need no pip packages;
  `shelly-watchdog.sh` uses `curl`. Credentials come from `/etc/signalk-automation.env` (§2.5).

---

## 10. Validation & soak

```
sudo systemctl status signalk avnav can0-nmea2000
ip -details link show can0
curl -s localhost:3000/signalk/v1/api/vessels/self | head
curl -sI localhost:8080 | head -1
candump -t d can0 | grep -m5 '"130306"\|130306'   # wind PGNs the plotter transmits
picocom -b 4800 -d 8 -p n /dev/rs485-1            # COM 1: expect NMEA 0183 sentences
picocom -b 38400 -d 8 -p n /dev/rs485-2           # COM 2: expect AIS (!AIVDM) sentences
```
For the last one, cross-check that PGN 130306 is appearing with a **source address other than
the instruments'** — that's the plotter's own claimed address, and it proves the TX path end to
end. If it never appears, check the `signalk-to-nmea2000` plugin's `Wind (130306)` conversion is
enabled and that wind is arriving from a non-N2K source (see §5).

Then leave it idle 24–48 h. No 5V rail, no HAT, no Pi PMIC — the soak should simply pass.

**Unattended power-cycle test — do this before the box goes back in the console:** pull the DC
plug, wait 10 s, restore it. The box must come back up on its own, with Signal K, AvNav and `can0`
all back within a couple of minutes. If it doesn't, *Restore AC Power Loss* isn't set (§1) — find
that out now, not at anchor.

---

## 11. Remote access (Tailscale)

Install **Tailscale** — a WireGuard mesh VPN. This is the right tool for a boat: **no port
forwarding**, no static IP, and it survives marina Wi-Fi and 4G where the uplink address changes
constantly or sits behind carrier-grade NAT.

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --advertise-routes=192.168.10.0/24
```

Log in at **login.tailscale.com**, then `tailscale ip -4` prints a stable `100.x.y.z` address.

| From any device on your tailnet | |
|---|---|
| Signal K | `http://100.x.y.z:3000` |
| AvNav | `http://100.x.y.z:8080` |
| SSH | `ssh pi@100.x.y.z` (or `ssh pi@bossy` with MagicDNS) |
| Shelly / instruments | `192.168.10.151` etc., via the advertised subnet |

**`--advertise-routes=192.168.10.0/24`** makes the box a subnet router, so you can reach the
BoatNetwork AP's clients — the Shelly, anything else on that side — without a separate tunnel.
Two follow-ups matter:

1. **Approve the route** in the admin console (*Machines → bossy → Edit route settings*) or it is
   advertised but not used.
2. On each client you want to use it from: `tailscale up --accept-routes` (macOS app: *Use Tailscale
   subnets*).

### The one setting people forget

**Disable key expiry for this node** in the admin console. The default is **180 days**, and an
unattended boat would silently drop off the tailnet mid-season — exactly when you need it. Machine
settings → *Disable key expiry*.

### Notes

- A **system service**, not a Signal K plugin — it sits underneath everything, so it also gives you
  remote access for RS485/CAN/automation debugging.
- Free for personal use (up to 100 devices); survives reboots.
- Poor uplink: Tailscale falls back to **DERP** relays. It still works, just slower — fine for
  Signal K and SSH, not for streaming.
- **Do not enable Tailscale Funnel** on this box. It publishes to the public internet, which is the
  thing the tailnet exists to avoid. Signal K's own security (§2) stays the only auth in front of
  :3000.
- `--accept-dns=false` is worth adding if MagicDNS interferes with the box resolving local names.
- If Tailscale ever becomes unsuitable, the equivalents are **ZeroTier** or **NetBird** — same idea,
  different account. WireGuard by hand needs a reachable endpoint, which a roaming boat does not have.

---

## 12. Gemini checklist — what we adopted, what we corrected

1. **Persistent serial naming** — *adopted.* Built-in `ttyS*` are already stable; the only USB
   device (CANable) is pinned to `can0` by udev (§5.1). The `by-path`/`by-id` symlink advice
   matters for USB serial adapters; ours is built-in, so this is a non-issue but the symlinks are
   added anyway for clarity (§6).
2. **Baud rate 4800 / 38400** — *confirmed.* COM 1 = 4800 for general instrument data, COM 2 =
   38400 for AIS, and **both are listen-only** — Signal K is configured input-only on each (§6).
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

---

## 14. Open items — audited 2026-11-16, gaps now documented

What was missing from the repo is now documented (new files) or pinned down; what remains genuinely
unknown is marked `[TODO-CONFIRM]` and must be settled on the boat.

| Item | Resolution |
|---|---|
| **Dropbox sync** | built: one-way **Dropbox → local** manuals library via rclone + systemd timer, served offline by nginx on **:8081**. Files and procedure in `pi-dock/dropbox/README.md`; only the one-time `rclone config` login is manual |
| **Grafana** | `pi-dock/grafana/README.md` — port **3001** (3000 is Signal K); install, data source and dashboard definitions `[TODO-CONFIRM]`, none captured |
| **KIP dashboards** | two survive and are committed: **`Engine`** (`kip-config.json`) and **`default`** (`11.0.0.json`); the other ~3 are lost — `pi-dock/kip/DASHBOARDS.md` |
| **Gauge zones** | `set-zones.py` already holds the real paths + bands — `signalk-zones/ZONES.md`; whether it was run on the Pi `[TODO-CONFIRM]` (idempotent, run once) |
| **fuel-economy** | paths documented in §2.9; instance mapping `[TODO-CONFIRM]` |

**Review note (verified against the repo, not taken on trust):** the handover's technical claims
all check out — `kip-config.json` really does hold the four `propulsion.port.*` gauges; `11.0.0.json`
really is 10 numeric / 6 linear / 1 compass / 1 wind-steer / 1 boolean / 2 text; the fuel-economy
plugin really does read `propulsion.{port,starboard}.fuel.rate` (m³/s, converted in-plugin to L/h)
and publish over `propulsion.main.fuel.economy` with a 30 s window and 0.5 m/s SOG floor; and the
`ZONES.md` bands match `set-zones.py` exactly. One gap it introduced has been closed in §2.10: the
`Engine` dashboard lives in `pi-dock/kip-config.json` and is injected via CDP, so it needed an
explicit restore step — and `chromium`/`nodejs` were missing from the package list entirely (§1.4),
despite every kiosk launcher calling `chromium`.

Everything else in the target stack is covered elsewhere in this document:
Debian (§1), Signal K (§2), AvNav (§3), the dock / bottom-bar apps (`dock.c` + `launch-*.sh` + labwc
autostart, §7), Shelly automation (§9), engine trends (`engine-trends/SPEC.md`, §13), N2K input and
output (§5), the two listen-only RS485 inputs (§6).

Note `engine-trends/SPEC.md` deliberately uses **SQLite, not InfluxDB/Grafana** — Grafana is a
renderer, not a time-series store (§13). If Grafana is revived, decide which of the two it serves.

---

## 15. Backups & snapshots — after it's built

**A disk image will not fit the 4 GB stick, and isn't the right artefact.** The NVMe is 128 GB and
a byte-for-byte image needs a target at least as large as the *used* space — several GB once AvNav
charts are aboard. Charts are also **encrypted and machine-bound**, so a restored image still needs
re-licensing. Imaging buys little.

What rebuilds this box quickly is its **configuration**:

```
sudo ./n100/snapshot-n100.sh              # -> /tmp/bossy-snapshot-YYYYMMDD-HHMM.tar.gz
sudo ./n100/snapshot-n100.sh /media/usb   # also copy to a stick
```

A few MB, capturing units, udev, nginx, hostapd, labwc autostart, `/usr/local/bin`, Signal K
`settings.json` + plugin configs + `applicationData` (the KIP dashboards), custom plugins, live
gauge zones, `can0`/RS485 state, and a `MANIFEST.txt` of `apt-mark showmanual` + `npm ls -g` +
enabled units.

**Secrets are redacted, not stored** — `rclone.conf` tokens and `signalk-automation.env` passwords
become `REDACTED`; re-run `rclone config` after a restore. Charts, manuals and media are excluded
by design.

If you *do* want a true bootable clone, the right target is the **spare 256 GB X15 NVMe** (§0) in an
M.2 enclosure — not a USB stick.



### 8.4 Multiple stored networks (roaming between home and boat)

NetworkManager holds any number of Wi-Fi profiles and joins whichever is in range, so
nothing has to be reconfigured when the box moves between the house and the boat. The
onboard card (`wlp3s0`) carries the uplink profile; the USB card carries the AP.

```
sudo nmcli connection add type wifi ifname wlp3s0 con-name Bossywifi ssid Bossywifi
sudo nmcli connection modify Bossywifi \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk '<passphrase>' \
  connection.autoconnect yes connection.autoconnect-priority 10 \
  ipv4.method auto ipv6.method ignore
```

- `autoconnect-priority 10` makes the boat uplink preferred over any lower-priority
  profile when both are visible.
- Add the home network the same way with a lower priority (or omit the priority).
- The SSID is **case-sensitive**: `BoatNetwork` (capital B, capital N) matches what the
  Pi broadcast, so already-provisioned Shelly modules and sensors keep working.
- At home the box normally has Ethernet (`enp4s0`) connected, so a home Wi-Fi profile is
  optional — Ethernet stays the default route and the onboard card is then free.
