# Verified on the wire — 2026-11-22

Measured directly against the unit (Mac on the USB Ethernet adapter at
`192.168.0.254/24`), to settle the assumptions the ESP32 relay firmware depends
on. All three passed.

## The page derives its host, it does not hardcode one

`assets/js/connection_manager.js`:

```js
var displayingIpAddress = location.hostname;   // line 41
var port = "9001";                             // line 61
var hostname = location.hostname;              // line 157
hostingClient = new Paho.MQTT.Client(hostname, Number(port), clientId);
```

So the browser connects to `ws://<whatever host served the page>:9001`. Serving
the page from `192.168.10.50` therefore makes it connect to
`ws://192.168.10.50:9001/mqtt` — exactly what the relay forwards. **No
rewriting proxy is needed**, which was the one assumption that could have
invalidated the relay design.

The WebSocket path `/mqtt` is the Paho default ("host is not a URI. Default:
'/mqtt'"), not something the page sets.

## Real connection counts

With the page loaded in a browser, established TCP connections to the unit:

| Port | Connections |
|---|---|
| 80 (HTTP) | **6** |
| 9001 (MQTT/WebSocket) | **2** |

Six is the browser per-host cap, and the page uses two MQTT clients (hosting and
displaying), not one. Both match `CFG_WEB_MAX_CONNS = 6` and
`CFG_MQTT_MAX_CONNS = 2` in `seakeeper-esp/relay/src/board_config.h`.

That is 8 relayed connections = 16 sockets, plus 2 listeners = 18, inside
`CONFIG_LWIP_MAX_SOCKETS = 20`.

## Live data confirmed

Read-only subscribe to `seakeeper/status/1` over WebSocket:

```
messages in 5s: 3
  {'flywheel_speed': 0, 'stabilize_enabled': 0}
```

The unit was powered down, hence 0 rpm — but the transport carries status, so
the topic and path are correct.

## Consequence for the N100

The launcher still points at `http://192.168.0.2/`, which is the *direct-cable*
topology from commit `4aa0074`. With the relay bridge the dock must load
`http://192.168.10.50/` instead, or the WebSocket host resolves to an address
the N100 cannot reach.

The repo copy is corrected; on the box the override file was set instead, which
the launcher already honours:

```sh
echo http://192.168.10.50/ > ~/.config/seakeeper-url
```

## End-to-end through the relay, verified

Measured from the N100 against `192.168.10.50` with the unit on the bridge:

| Check | Result |
|---|---|
| `GET /` | 200, **45,851 bytes** — byte-identical to direct |
| `GET /assets/js/d3.v3.min.js` | 200, 151,143 bytes |
| `GET /garmin/config.json` | 200, 156 bytes |
| WebSocket upgrade on 9001 | `101 Switching Protocols` |
| MQTT CONNECT | `20 02 00 00` (accepted) |
| MQTT PINGREQ | `d0 00` |
| Status stream | continuous 808-byte PUBLISH frames (~5/s) |

One defect was found and fixed during this test: the relay stalled after
exactly one buffer (1024 bytes) on any larger response, because the pump's
read condition excluded a buffer that was full but fully sent. See the
`pump()` comment in `seakeeper-esp/relay/src/relay.c` and
`seakeeper-esp/relay/tools/pump_test.c`, which reproduces it on a host.

## The page must be loaded from the unit's own address

Serving the page from `192.168.10.50` gives a UI that renders and responds to
touch, but with blank model / run-hours and dead power and speed commands.
That is not a relay fault.

The unit publishes its own address:

```
seakeeper/gyros -> {"gyros":[{"ip_address":"192.168.0.2","seakeeper_instance":1}]}
```

and `connection_manager.js` only enters its normal path when the advertised
address equals the address the page was served from:

```js
if (seakeeperList[index].ip_address === location.hostname) {   // line 705
    hostingInstance   = ...;
    displayingIpAddress = seakeeperList[index].ip_address;
    ...
}
```

Loaded from `192.168.10.50` the comparison fails, the display client is never
established, and the status topics the gauges and command handling depend on
are never subscribed. Measured from the N100: one WebSocket connection instead
of two, and no status traffic.

**Fix:** load `http://192.168.0.2/` and redirect that destination to the bridge
on the N100, so `location.hostname` matches the advertised address and the
bridge stays a byte pipe:

```sh
iptables -t nat -A OUTPUT -d 192.168.0.2 -j DNAT --to-destination 192.168.10.50
```

Installed as `n100/seakeeper-redirect.service` (idempotent, enabled at boot).
Verified: two WebSocket connections, the display client receiving 103,409
bytes of status.

## In service — final numbers

| Check | Result |
|---|---|
| Page load through the relay | **0.22 s** for 45,851 bytes (~205 KB/s) |
| Page MQTT connections | 2 (hosting + displaying) |
| Status received by the display client | 161,335 bytes and climbing |
| Redirect service | `enabled`, `active` |

The drain-per-wake and 2 KB buffer change took page load from ~1.0 s to
0.22 s. Before that change the pump moved one 1 KB buffer per `select()`, so
throughput was one buffer per Wi-Fi round trip (~45 KB/s measured against a
15.5 ms average RTT).

### The "lost connection" was physical

Twice during commissioning the page lost everything at once. Each time the
board was unreachable on Wi-Fi as well (100% ping loss) and the RJ45 LEDs were
dark, and once back up the relay failed in 39 ms rather than 5 s — an instant
failure means the Ethernet link itself is down, where a 5 s failure means the
link is up but the unit is silent.

Use that as the first diagnostic:

| Relay failure | Meaning |
|---|---|
| **~39 ms, 000** | Ethernet link down — cable, socket, or unit off |
| **~5 s, 000** | link up, unit not answering |
| **200** | working |

The board losing power entirely is still the leading suspect, and the buck
converter feeding it has now done this twice.



