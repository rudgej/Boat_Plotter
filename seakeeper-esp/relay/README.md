# SeaKeeper relay

Purpose-built ESP-IDF firmware for the WT32-ETH01 that sits between BoatNetwork
and the SeaKeeper. It replaces the bridge/router firmware on that board.

## Why this exists

The previous firmware did destination NAT only (`192.168.10.1:19000` ->
`192.168.0.2:80`). Because no source NAT was performed, the SeaKeeper saw packets
from `192.168.10.1` and tried to reply to a host it has no route to, ARPing for
it forever. Packet captures on the bridge port confirmed this.

This firmware avoids the problem entirely: **the ESP32 opens the upstream socket
itself**, so the connection is sourced from its Ethernet address
`192.168.0.254`, which is in the SeaKeeper's own `/24`. The unit can answer it
directly with no gateway configured and no NAT anywhere.

The board stays a dumb pipe - it forwards bytes, it does not interpret them. All
configuration lives on the N100 side (the dock URL, the page, MQTT topics).

## Topology

```
N100 (192.168.10.1)  --Wi-Fi-->  ESP32 (192.168.10.50)  --Ethernet-->  SeaKeeper (192.168.0.2)
```

| Port on BoatNetwork | Forwarded to | Purpose |
|---------------------|--------------|---------|
| `192.168.10.50:80`   | `192.168.0.2:80`   | SeaKeeper web UI |
| `192.168.10.50:9001` | `192.168.0.2:9001` | MQTT over WebSocket (live data + commands) |

The dock tab already points at `http://192.168.10.50/`, so nothing on the N100
needs to change.

## Configuration

There is none, deliberately. This is a single-purpose component for one board
in one boat, so every value is a fixed literal in `src/board_config.h` - there
are no runtime settings, no build-time overrides and no config file. Changing
the topology means editing that file and reflashing.

| Constant | Value | Why it is that value |
|----------|-------|----------------------|
| `CFG_WIFI_SSID` | `BoatNetwork` | the N100's AP |
| `CFG_WIFI_PASSWORD` | *(empty)* | fill in; the AP is WPA2 |
| `CFG_STA_IP` | `192.168.10.50` | outside the AP's `.100`-`.200` pool |
| `CFG_ETH_IP` | `192.168.0.254` | same `/24` as the unit, used as the source address |
| `CFG_UPSTREAM_HOST` | `192.168.0.2` | the SeaKeeper |
| `CFG_PORT_WEB` / `CFG_PORT_MQTT` | `80` / `9001` | the only two services needed |

The Wi-Fi password is the one value you must edit. If it is left empty the
firmware logs a warning at boot and will not associate with the WPA2 AP.

## Network boundary

The board is deliberately closed in both directions:

- Listeners bind to `192.168.10.50` only, so ports 80 and 9001 are **not**
  reachable from the Ethernet side. They are not bound to `INADDR_ANY`.
- Upstream sockets are bound to `192.168.0.254` before connecting, so the unit
  always sees a source address in its own `/24` and can reply without a gateway.
- A connection with no traffic in either direction for 10 minutes is dropped,
  so a stalled client cannot hold one of the six relay slots until reboot.

## Wiring (WT32-ETH01)

| Signal | GPIO |
|--------|------|
| RMII clock in | 0 |
| PHY power enable | 16 (driven high at boot) |
| MDC | 23 |
| MDIO | 18 |
| PHY address | 1 |

Connect the board's RJ45 to the SeaKeeper and power it from the existing boat
supply. There is no reset line; the PHY is brought up by software.

## Build and flash

**The board has no USB socket.** It is programmed through the header pins with a
3.3 V USB-to-UART adapter held on with pogo pins. Wiring (TX/RX/GND/3V3) is in
[`../SETUP.md`](../SETUP.md) §1 - it is the same harness used for the previous
firmware.

PlatformIO project, same workflow as the other ESP32 nodes:

```sh
cd seakeeper-esp/relay
pio run                     # build
./flash.sh                  # build + upload (prompts for the bootloader steps)
pio device monitor          # 115200 serial log
```

or step by step:

```sh
pio run
pio run -t upload --upload-port /dev/cu.usbserial-XXXX
pio device monitor --port /dev/cu.usbserial-XXXX --baud 115200
```

### There is no auto-reset circuit - you must do it by hand

PlatformIO normally resets the board into download mode over DTR/RTS. Those
lines are not wired, so it cannot. Before **every** upload:

1. Wire `IO0` (right header, 3rd pin) to `GND` and leave it there.
2. Tap `EN` (left header, 1st pin) to `GND` to reset into download mode.
3. Run the upload. It will sit waiting for the chip until step 2 has happened.
4. **Disconnect IO0 from GND**, then tap `EN` to `GND` again to run the firmware.

> GPIO0 is also the LAN8720 reference clock input, so IO0 must never be left
> grounded while the bridge is running - watchdog reset loop if it is.

`./flash.sh` performs the build, finds the adapter, and prints these steps at
the right moments so nothing is left grounded by accident.

`platform = espressif32@6.12.0` is pinned, so the toolchain (ESP-IDF 5.5.0) is
downloaded once and then fixed - a platform update cannot silently change this
build. No system-wide `idf.py` install is needed.

Flashing on this unit is done through hand-held pogo pins, so verify as much as
possible before each cycle:

1. Build locally first - the compiler catches what a stub type check cannot.
2. `pio device monitor` straight after the flash reads the bring-up log in the
   same pass; the board must be powered from 5 V and IO0 released before reset.

Serial port on macOS: `ls /dev/cu.usb*`.

## Expected log

```
app: ethernet static IP 192.168.0.254/255.255.255.0
app: wifi static IP 192.168.10.50/255.255.255.0 gw 192.168.10.1
app: wifi started, joining "BoatNetwork"
relay: web: listening on port 80 -> 192.168.0.2:80
relay: mqtt: listening on port 9001 -> 192.168.0.2:9001
app: ready: http://192.168.10.50/  (mqtt ws :9001)
app: wifi up: 192.168.10.50
```

## Acceptance test

Run from the N100:

```sh
# 1. web UI reachable
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.10.50/     # expect 200

# 2. live data over MQTT/WebSocket
#    (paho-mqtt, transport="websockets", ws path "/mqtt", port 9001)
#    subscribe seakeeper/status/1 - expect ~4-5 messages/sec, flywheel_speed present
```

Then command round-trip: publish `{"power":1}` to `seakeeper/request/1` and
confirm `power` changes in the status stream; same for `{"stabilize":1}` and
`{"flywheel_speed":1}` (min 7600) / `{"flywheel_speed":0}` (max 9700).

Failure modes to check for:

- `relay: web: listening ...` never appears -> bind failed, look for the errno.
- Client connects but nothing returns -> `upstream ... unreachable`, meaning
  Ethernet link or addressing is wrong.
- Works then drops -> Wi-Fi power save; flash has it disabled by default in this
  firmware, check the router's client isolation is off.

## Open notes

- Keep `CONFIG_LWIP_MAX_SOCKETS` at 16 or above: each relayed connection uses
  two sockets (client + upstream).
- The relay is deliberately single-threaded per connection with a 6-connection
  cap; that is more than the UI needs and keeps RAM predictable.
- This firmware does no routing between the two networks. The SeaKeeper is
  reachable only through the two forwarded ports.
