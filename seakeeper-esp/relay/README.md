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

Everything adjustable is in `main/board_config.h`:

| Setting | Default | Notes |
|---------|---------|-------|
| `CFG_WIFI_SSID` | `BoatNetwork` | |
| `CFG_WIFI_PASSWORD` | *(empty)* | Empty means open network |
| `CFG_STA_IP` | `192.168.10.50` | Outside the AP's `.100`-`.200` pool |
| `CFG_ETH_IP` | `192.168.0.254` | Must stay inside the SeaKeeper's `/24` |
| `CFG_UPSTREAM_HOST` | `192.168.0.2` | The SeaKeeper |

### Credentials without committing them

Create `main/secrets.h` (git-ignored) and it is picked up automatically:

```c
#pragma once
#define CFG_WIFI_PASSWORD "the-real-password"
```

Alternatively override at build time without editing anything:

```sh
idf.py -DCFG_WIFI_PASSWORD='"the-real-password"' build
```

No source change is needed to rotate the password - rebuild and reflash.

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

Requires ESP-IDF v5.x.

```sh
cd seakeeper-esp/relay
idf.py set-target esp32
idf.py build
idf.py -p /dev/tty.usbserial-XXXX flash monitor
```

Flashing on this unit is done through hand-held pogo pins, so verify as much as
possible before each cycle:

1. Check the build log for warnings - they are cheap, reflashing is not.
2. Prefer running `idf.py monitor` after the flash to read the bring-up log in
   the same pass.

Serial port on macOS: `ls /dev/tty.usb*`.

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
