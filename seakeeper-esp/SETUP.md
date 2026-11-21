# Seakeeper ↔ BoatNetwork bridge (WT32-ETH01)

The Seakeeper 5" display has an Ethernet socket but no Wi-Fi. A **WT32-ETH01
V1.4** (ESP32 + LAN8720 Ethernet) is flashed with
[martin-ger/esp32_ethernet_router](https://github.com/martin-ger/esp32_ethernet_router)
so it:

- joins **BoatNetwork** as a Wi-Fi **station** (uplink),
- provides a wired Ethernet **LAN** on its RJ45 socket (the Seakeeper plugs in
  here),
- **NATs** the Seakeeper onto BoatNetwork and **port-forwards** the Seakeeper's
  web UI.

The Pi then just opens `http://192.168.10.50/` (the ESP32's static BoatNetwork
IP) and the request is forwarded to the Seakeeper's web page. No software is
written for this bridge — the firmware is prebuilt upstream; only config is
applied via its serial console / web UI.

Prebuilt firmware binaries are committed in `firmware/` (ESP-IDF v5.5.4,
identical to the upstream `firmware/` directory).

---

## 1. Wiring — USB-to-TTL flasher → WT32-ETH01

The WT32-ETH01 has **no USB port**, so it is programmed through its header pins
with a **3.3 V** USB-to-UART adapter (FTDI / CP2102 / CH340). Set the adapter's
VCC jumper to **3.3 V**.

The board has two rows of header pins. With the RJ45 socket on the left:

| Row | Pins (top → bottom) |
|-----|---------------------|
| **Right header** | `TXD`, `RXD`, `IO0`, `GND`, IO39, IO36, IO15, IO14, IO12, IO35, IO4, IO2, GND |
| **Left header** | `EN`, `GND`, `3V3`, EN, CFG, 485_EN, RXD, TXD, 3V3, GND, `5V`, LINK |

Connect **four** wires (plus power):

| USB-TTL adapter | WT32-ETH01 pin | Notes |
|-----------------|----------------|-------|
| `TX`  | `RXD` (right header, 2nd pin)  | **crossed** |
| `RX`  | `TXD` (right header, 1st pin)  | **crossed** |
| `GND` | `GND` (right header, 4th pin)  | common ground |
| `3V3` | `3V3` (left header, 3rd pin)   | power — **or** adapter `5V` → board `5V` (left header, 11th pin) |

> Do **not** feed a 5 V logic signal into TX/RX — the ESP32 is 3.3 V logic.
> For flashing, 3V3 power is fine. For running Wi-Fi, power from **5 V** instead
> (the board's regulator feeds the ESP32 + LAN8720 more cleanly).

### Entering bootloader (download) mode

The board has no reset button and no auto-program circuit, so do it by hand:

1. Wire `IO0` (right header, 3rd pin) → `GND` and **leave it connected**.
2. Power the board on, or tap `EN` (left header, 1st pin) to `GND` briefly to
   reset it.
3. The ESP32 now boots into download mode — run the flash.
4. After flashing: **disconnect IO0 from GND**, then reset (tap `EN` → `GND`) to
   run the firmware.

> GPIO0 doubles as the LAN8720 Ethernet reference-clock input, so it must **not**
> be held low while the bridge is running.

---

## 2. Flash

```bash
cd seakeeper-esp
./flash.sh                      # auto-detects the USB serial port
ERASE=1 ./flash.sh              # full erase (wipes saved Wi-Fi creds too)
```

The script writes `bootloader.bin` @ `0x1000`, `partition-table.bin` @ `0x8000`,
`ota_data_initial.bin` @ `0xf000`, `esp32_eth_router.bin` @ `0x20000`
(ESP32, 460800 baud).

---

## 3. First boot — automatic onboarding AP

With no Wi-Fi credentials stored (factory-fresh), the firmware brings up an
onboarding network on the **Ethernet** port at `192.168.4.1/24` with DHCP and a
captive-portal config page:

1. Plug a laptop into the WT32-ETH01's RJ45 socket, DHCP enabled.
2. Browse to `http://192.168.4.1` (or `http://esp32-eth-router.local` via mDNS).
3. Enter the upstream Wi-Fi SSID + password (BoatNetwork on the boat; home Wi-Fi
   for the bench test), save. The router reboots and joins.

The serial console (115200) gives the same control:

```
set_sta <ssid> <password>
restart
```

---

## 4. Bench test on the home network

1. Flash, then open the serial console at **115200** (adapter RX/TX still wired).
2. `set_sta <home-wifi> <home-pass>` then `restart`.
3. Watch `show status` — the uplink should connect and get a home DHCP lease.
4. Optional full-path test: plug a laptop into the RJ45 socket; it should get a
   `192.168.4.x` lease and reach the internet *through* the ESP32 (NAT). Browse
   `http://192.168.4.1` to confirm the web UI from the Ethernet side.

---

## 5. Seakeeper preset (applied 2026-11-01)

The bridge is now pre-configured for ChatGPT's assumed Seakeeper IP (`172.16.102.1`):

- Wi-Fi uplink: BoatNetwork, static `192.168.10.50`.
- Ethernet downlink: `172.16.102.254/24`, DHCP + NAT on (pool `172.16.102.1-100`).
- Admin UI moved to port 8080 → `http://192.168.10.50:8080/`.
- Port forward: `192.168.10.50:80 -> 172.16.102.1:80`. **Wrong target — see the
  correction in §7.** The unit answers on `192.168.0.2`; a revived bridge needs
  `portmap add TCP 80 192.168.0.2 80` and a `192.168.0.254/24` downlink.

The Pi's Seakeeper button (`http://192.168.10.50/`) therefore forwards to the
Seakeeper web UI.

**On the boat:**
1. Power the ESP32, plug the Seakeeper's Ethernet into its RJ45 socket.
2. Confirm the Seakeeper's real IP. If it is a DHCP client it will get a lease in
   `172.16.102.1-100` (very likely `.1`, matching the preset). If it is a
   different static IP, change one number via the serial console or the admin
   UI at `http://192.168.10.50:8080/`:
   ```
   portmap add TCP 80 <seakeeper-ip> 80
   restart
   ```
3. Tap the dock's Seakeeper button.

If the Seakeeper turns out to be a **DHCP client**, skip `set_ap_ip` (leave the
default `192.168.4.1/24`; the Seakeeper gets `192.168.4.2`) and use:

```
portmap add TCP 80 192.168.4.2 80
restart
```

Either way the Pi reaches it at **`http://192.168.10.50/`** (the Pi's
`launch-seakeeper.sh` kiosk already points there).

---

## 6. Home-test result (verified 2026-11-01)

- Flashed clean (ESP32-D0WD-V3, MAC `7c:d5:44:3b:ee:78`).
- Configured for BoatNetwork; on reboot it associated (`hostapd_cli -i wlan1
  all_sta` shows the MAC), got static `192.168.10.50`, and answers HTTP on
  `http://192.168.10.50/` (title `ESP32 Ethernet Router`).
- Ethernet downlink up: `192.168.4.1` with DHCP + NAT enabled, mDNS
  `seakeeper-bridge.local`.
- End-to-end NAT path verified: a laptop on the Ethernet side (`192.168.4.x`)
  loaded `http://192.168.4.1` and pinged the Pi at `192.168.10.1` (~8 ms) —
  Mac → ESP32 (Ethernet) → NAT → BoatNetwork → Pi works.
- Seakeeper preset applied (§5): Ethernet moved to `172.16.102.254`, admin UI on
  `:8080`, port 80 forwarded to `172.16.102.1`. Verified: `http://192.168.10.50/`
  now times out (forward target absent), `http://192.168.10.50:8080/` serves the
  admin UI.

**Resolved 2026-11-21:** the unit is a **DHCP client** and answers on **`192.168.0.2`**.
It was never at `172.16.102.1`. See `seakeeper-link.md` at the repo root for the
measurements, the web UI, and the MQTT interface.

## 7. Direct connection — no bridge (added 2026-11-19)

The bridge is no longer the only option. The box's second Ethernet port `enp2s0` now carries
**172.16.102.254/24**, the same subnet this bridge used on its downlink, so the Seakeeper can be
cabled **straight into the box** and sees exactly the network it was pre-configured for.

- Direct: cable → `enp2s0`, browse **`http://192.168.0.2/`** from the box.

  > **CORRECTION 2026-11-21.** The direct link was measured on the boat: the unit is a
  > DHCP client that answers on **`192.168.0.2`** — web UI on 80, SSH on 22, MQTT over
  > WebSocket on 9001. It was never at `172.16.102.1`; that figure started as a guess in
  > §5 of this document and was inherited by the box config and by the bridge preset.
  > Everything below that mentions `172.16.102.x` is that original guess, kept for the
  > record. Working configuration and evidence: `seakeeper-link.md` at the repo root.
- Via the bridge: unchanged, browse **`http://192.168.10.50/`**.

The two are interchangeable, which is the point: the assumed `.1` works either way. Full details,
including the DHCP fallback if the Seakeeper turns out to be a DHCP client, are in
`MIGRATION.md` §18. `enp2s0` is `ipv4.never-default`, so it can never steal the internet route.

## Recovery

- **Misconfigured?** `factory_reset` on the serial console, or
  `ERASE=1 ./flash.sh` and reconfigure.
- **Console lock-up:** re-enter bootloader (IO0→GND + reset) and re-flash.
