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
